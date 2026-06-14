import Foundation
@testable import RepoPrompt
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

    func testExecute_missingOp_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(args: [:], scanner: mockScanner)
        XCTAssertEqual(result["error"] as? String, "Missing or empty required parameter 'op'")
    }

    func testExecute_emptyOp_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(args: ["op": ""], scanner: mockScanner)
        XCTAssertEqual(result["error"] as? String, "Missing or empty required parameter 'op'")
    }

    func testExecute_unknownOp_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(args: ["op": "unknown"], scanner: mockScanner)
        XCTAssertEqual(result["error"] as? String, "Unknown op 'unknown'. Valid ops: list_sessions, search, time")
    }

    // MARK: - list_sessions

    func testListSessions_emptyResults() async throws {
        mockScanner.scanResults = []
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        XCTAssertEqual(result["total_sessions"] as? Int, 0)
        XCTAssertEqual(result["truncated"] as? Bool, false)
        XCTAssertEqual((result["sessions"] as? [[String: Any]])?.count, 0)
    }

    func testListSessions_returnsAllFields() async throws {
        let record = makeRecord(name: "Test Session", agentKindRaw: "claudeCode", agentModelRaw: "claude-sonnet-4")
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let sessions = result["sessions"] as? [[String: Any]]
        XCTAssertEqual(sessions?.count, 1)

        let session = try XCTUnwrap(sessions?[0])
        XCTAssertEqual(session["session_id"] as? String, record.id.uuidString)
        XCTAssertEqual(session["session_name"] as? String, "Test Session")
        XCTAssertEqual(session["workspace_name"] as? String, "TestWorkspace")
        XCTAssertEqual(session["agent_kind"] as? String, "claudeCode")
        XCTAssertEqual(session["agent_model"] as? String, "claude-sonnet-4")
        XCTAssertEqual(session["active_duration_seconds"] as? Int, 0)
        XCTAssertEqual(session["turn_count"] as? Int, 1)
        XCTAssertEqual(session["tool_call_count"] as? Int, 0)
        XCTAssertEqual(session["had_errors"] as? Bool, false)
        XCTAssertNotNil(session["first_activity_at"])
        XCTAssertNotNil(session["last_activity_at"])
    }

    func testListSessions_truncation() async throws {
        let records = (0 ..< 50).map { makeRecord(name: "S\($0)") }
        mockScanner.scanResults = [makeScanResult(records: records)]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "limit": 20],
            scanner: mockScanner
        )
        XCTAssertEqual(result["total_sessions"] as? Int, 50)
        XCTAssertEqual(result["truncated"] as? Bool, true)
        XCTAssertEqual((result["sessions"] as? [[String: Any]])?.count, 20)
    }

    func testListSessions_defaultLimit() async throws {
        // Default limit is 30.
        let records = (0 ..< 50).map { makeRecord(name: "S\($0)") }
        mockScanner.scanResults = [makeScanResult(records: records)]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        XCTAssertEqual(result["total_sessions"] as? Int, 50)
        XCTAssertEqual(result["truncated"] as? Bool, true)
        XCTAssertEqual((result["sessions"] as? [[String: Any]])?.count, 30)
    }

    func testListSessions_maxLimit100() async throws {
        let records = (0 ..< 150).map { makeRecord(name: "S\($0)") }
        mockScanner.scanResults = [makeScanResult(records: records)]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "limit": 200],
            scanner: mockScanner
        )
        XCTAssertEqual(result["truncated"] as? Bool, true)
        XCTAssertEqual((result["sessions"] as? [[String: Any]])?.count, 100)
    }

    func testListSessions_sortByDuration() async throws {
        let r1 = makeRecord(name: "Short", activeDurationSeconds: 100)
        let r2 = makeRecord(name: "Long", activeDurationSeconds: 500)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "sort": "duration"],
            scanner: mockScanner
        )
        let sessions = result["sessions"] as? [[String: Any]]
        XCTAssertEqual(sessions?[0]["session_name"] as? String, "Long")
        XCTAssertEqual(sessions?[1]["session_name"] as? String, "Short")
    }

    func testListSessions_invalidSort_returnsError() async throws {
        mockScanner.scanResults = []
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "sort": "bogus"],
            scanner: mockScanner
        )
        XCTAssertEqual(result["error"] as? String, "Invalid 'sort' value 'bogus'. Valid values: last_activity, duration, turn_count")
    }

    func testListSessions_sortByTurnCount() async throws {
        let r1 = makeRecord(name: "Few", itemCount: 2)
        let r2 = makeRecord(name: "Many", itemCount: 10)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions", "sort": "turn_count"],
            scanner: mockScanner
        )
        let sessions = result["sessions"] as? [[String: Any]]
        XCTAssertEqual(sessions?[0]["session_name"] as? String, "Many")
        XCTAssertEqual(sessions?[1]["session_name"] as? String, "Few")
    }

    func testListSessions_filesTouched() async throws {
        let record = makeRecord(name: "S1", keyPaths: ["src/main.swift", "lib/utils.swift"])
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let session = (result["sessions"] as? [[String: Any]])?.first
        let files = session?["files_touched"] as? [String]
        XCTAssertEqual(files, ["lib/utils.swift", "src/main.swift"]) // sorted
    }

    func testListSessions_lastRunState() async throws {
        let record = makeRecord(name: "S1", lastRunStateRaw: "completed")
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let session = (result["sessions"] as? [[String: Any]])?.first
        XCTAssertEqual(session?["last_run_state"] as? String, "completed")
    }

    func testListSessions_defaultSortsByLastActivityDescending() async throws {
        let r1 = makeRecord(name: "Old", savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let r2 = makeRecord(name: "New", savedAt: Date(timeIntervalSince1970: 1_700_001_000))
        mockScanner.scanResults = [makeScanResult(records: [r1, r2])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let sessions = result["sessions"] as? [[String: Any]]
        // Default sort is last_activity descending — newest first.
        XCTAssertEqual(sessions?[0]["session_name"] as? String, "New")
        XCTAssertEqual(sessions?[1]["session_name"] as? String, "Old")
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
        let session = (result["sessions"] as? [[String: Any]])?.first
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(session?["first_activity_at"] as? String, formatter.string(from: firstActivity))
        XCTAssertEqual(session?["last_activity_at"] as? String, formatter.string(from: lastActivity))
    }

    func testListSessions_toolCallCountFromMetadata() async throws {
        let record = makeRecord(name: "S1", toolCallCount: 7)
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let session = (result["sessions"] as? [[String: Any]])?.first
        XCTAssertEqual(session?["tool_call_count"] as? Int, 7)
    }

    func testListSessions_hadErrorsTrue() async throws {
        let record = makeRecord(name: "S1", hasUnknownContent: true)
        mockScanner.scanResults = [makeScanResult(records: [record])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "list_sessions"],
            scanner: mockScanner
        )
        let session = (result["sessions"] as? [[String: Any]])?.first
        XCTAssertEqual(session?["had_errors"] as? Bool, true)
    }

    func testListSessions_passesMetadataFiltersToScanner() async throws {
        let record = makeRecord(name: "S1")
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

        XCTAssertEqual(result["total_sessions"] as? Int, 1)
        let request = try XCTUnwrap(mockScanner.filterRequests.first)
        XCTAssertEqual(request.workspace, "FilterWorkspace")
        XCTAssertEqual(request.agentKind, "claude")
        XCTAssertEqual(request.model, "sonnet")
        XCTAssertEqual(request.filePath, "Sources/App.swift")
        XCTAssertEqual(request.from, HistoryMCPToolService.parseDate("2026-06-10T12:00:00Z"))
        XCTAssertEqual(request.to, HistoryMCPToolService.parseDate("2026-06-11T12:00:00Z"))
    }

    // MARK: - search

    func testSearch_missingQuery_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search"],
            scanner: mockScanner
        )
        XCTAssertEqual(result["error"] as? String, "Missing or empty required parameter 'query'")
    }

    func testSearch_emptyQuery_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": ""],
            scanner: mockScanner
        )
        XCTAssertEqual(result["error"] as? String, "Missing or empty required parameter 'query'")
    }

    func testSearch_whitespaceOnlyQuery_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "   \t  "],
            scanner: mockScanner
        )
        XCTAssertEqual(result["error"] as? String, "Missing or empty required parameter 'query'")
    }

    func testSearch_invalidSource_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "test", "source": "bogus"],
            scanner: mockScanner
        )
        XCTAssertEqual(result["error"] as? String, "Invalid 'source' value 'bogus'. Valid values: activities, summaries, all")
    }

    func testSearch_noMatches() async throws {
        let record = makeRecord(name: "S1")
        mockScanner.scanResults = [makeScanResult(records: [record])]
        mockScanner.transcriptProvider = { _ in .empty }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "nonexistent"],
            scanner: mockScanner
        )
        XCTAssertEqual(result["total_matches"] as? Int, 0)
        XCTAssertEqual(result["truncated"] as? Bool, false)
        XCTAssertEqual((result["results"] as? [[String: Any]])?.count, 0)
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
        XCTAssertEqual(result["total_matches"] as? Int, 1)

        let results = result["results"] as? [[String: Any]]
        XCTAssertEqual(results?.count, 1)
        XCTAssertEqual(results?[0]["source"] as? String, "activity")
        XCTAssertEqual(results?[0]["role"] as? String, "assistant")
        XCTAssertEqual(results?[0]["turn_index"] as? Int, 0)
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
        XCTAssertEqual(result["total_matches"] as? Int, 1)
        let results = result["results"] as? [[String: Any]]
        XCTAssertEqual(results?[0]["source"] as? String, "summary")
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
        XCTAssertEqual(result["total_matches"] as? Int, 1)
        let results = result["results"] as? [[String: Any]]
        XCTAssertEqual(results?[0]["source"] as? String, "summary")
        XCTAssertNotNil(results?[0]["snippet"] as? String)
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
        XCTAssertEqual(result["total_matches"] as? Int, 1)
        let results = result["results"] as? [[String: Any]]
        XCTAssertEqual(results?[0]["source"] as? String, "activity")
    }

    func testSearch_sourceFilterActivities() async throws {
        // Summary has the match but source=activities should skip it.
        let record = makeRecord(name: "S1")
        let scanResult = makeScanResult(records: [record])
        mockScanner.scanResults = [scanResult]

        let turn = AgentTranscriptTurn(
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
        mockScanner.transcriptProvider = { _ in AgentTranscript(turns: [turn]) }

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "rate limiting", "source": "activities"],
            scanner: mockScanner
        )
        XCTAssertEqual(result["total_matches"] as? Int, 0)
    }

    func testSearch_sourceFilterSummaries() async throws {
        // Activity has the match but source=summaries should skip it.
        let record = makeRecord(name: "S1")
        let scanResult = makeScanResult(records: [record])
        mockScanner.scanResults = [scanResult]

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
            args: ["op": "search", "query": "rate limiting", "source": "summaries"],
            scanner: mockScanner
        )
        XCTAssertEqual(result["total_matches"] as? Int, 0)
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
        XCTAssertEqual(result["total_matches"] as? Int, 30)
        XCTAssertEqual(result["truncated"] as? Bool, true)
        XCTAssertEqual((result["results"] as? [[String: Any]])?.count, 10)
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
            args: ["op": "search", "query": "unicorn", "session_id": targetID.uuidString],
            scanner: mockScanner
        )
        XCTAssertEqual(result["total_matches"] as? Int, 1)
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
        XCTAssertEqual(result["total_matches"] as? Int, 1)
        let results = result["results"] as? [[String: Any]]
        XCTAssertEqual(results?.count, 1)
        XCTAssertEqual(results?[0]["session_name"] as? String, "OKSession")
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
            args: ["op": "search", "query": "rate limiting bug"],
            scanner: mockScanner
        )
        let results = result["results"] as? [[String: Any]]
        XCTAssertEqual(results?.count, 1)
        XCTAssertEqual(results?[0]["turn_request_text"] as? String, "Find all rate limiting bugs")
    }

    func testSearch_turnRequestTextNilWhenNoRequest() async throws {
        let record = makeRecord(name: "S1")
        let scanResult = makeScanResult(records: [record])
        mockScanner.scanResults = [scanResult]

        // Turn without a request — turn_request_text should be nil.
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
            args: ["op": "search", "query": "dragonfruit"],
            scanner: mockScanner
        )
        let results = result["results"] as? [[String: Any]]
        XCTAssertEqual(results?.count, 1)
        // turn_request_text is nil for turns without a user request.
        XCTAssertEqual(results?[0]["turn_request_text"] as? String, nil)
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
        let results = result["results"] as? [[String: Any]]
        XCTAssertEqual(results?[0]["role"] as? String, "tool")
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
        XCTAssertEqual(result["total_matches"] as? Int, 1)
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
        XCTAssertEqual(result["total_matches"] as? Int, 3)
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

        XCTAssertEqual(result["total_matches"] as? Int, 0)
        let request = try XCTUnwrap(mockScanner.filterRequests.first)
        XCTAssertEqual(request.from, HistoryMCPToolService.parseDate("2026-01-15T00:00:00Z"))
        XCTAssertEqual(request.to, HistoryMCPToolService.parseDate("2026-01-20T00:00:00Z"))
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

        XCTAssertEqual(result["total_matches"] as? Int, 0)
        let request = try XCTUnwrap(mockScanner.filterRequests.first)
        XCTAssertEqual(request.workspace, "MyProject")
    }

    func testSearch_invalidSessionID_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "search", "query": "test", "session_id": "not-a-uuid"],
            scanner: mockScanner
        )
        XCTAssertNotNil(result["error"])
        XCTAssertEqual(result["error"] as? String, "Invalid session_id: expected UUID format")
    }

    func testTime_missingGroupBy_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time"],
            scanner: mockScanner
        )
        XCTAssertEqual(result["error"] as? String, "Missing or empty required parameter 'group_by'")
    }

    func testTime_invalidGroupBy_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "year"],
            scanner: mockScanner
        )
        XCTAssertEqual(result["error"] as? String, "Invalid 'group_by' value 'year'. Valid values: day, week, month, session, workspace")
    }

    func testTime_invalidSessionID_returnsError() async throws {
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day", "session_id": "not-a-uuid"],
            scanner: mockScanner
        )
        XCTAssertNotNil(result["error"])
        XCTAssertEqual(result["error"] as? String, "Invalid session_id: expected UUID format")
    }

    func testTime_emptyResults() async throws {
        mockScanner.scanResults = []
        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day"],
            scanner: mockScanner
        )
        XCTAssertEqual(result["total_sessions"] as? Int, 0)
        XCTAssertEqual(result["total_active_duration_seconds"] as? Int, 0)
        XCTAssertEqual((result["groups"] as? [[String: Any]])?.count, 0)
    }

    func testTime_groupByDay() async throws {
        let date1 = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14
        let date2 = Date(timeIntervalSince1970: 1_700_000_000 + 86400) // next day
        let r1 = makeRecord(name: "S1", activeDurationSeconds: 300, savedAt: date1)
        let r2 = makeRecord(name: "S2", activeDurationSeconds: 600, savedAt: date1)
        let r3 = makeRecord(name: "S3", activeDurationSeconds: 400, savedAt: date2)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2, r3])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "day"],
            scanner: mockScanner
        )
        XCTAssertEqual(result["total_sessions"] as? Int, 3)
        XCTAssertEqual(result["total_active_duration_seconds"] as? Int, 1300)

        let groups = result["groups"] as? [[String: Any]]
        XCTAssertEqual(groups?.count, 2)

        // Find the group with 2 sessions (same day as date1).
        let twoSessionGroup = groups?.first { $0["sessions"] as? Int == 2 }
        XCTAssertNotNil(twoSessionGroup)
        XCTAssertEqual(twoSessionGroup?["active_duration_seconds"] as? Int, 900)
        XCTAssertEqual(twoSessionGroup?["turn_count"] as? Int, 2) // 1 + 1 itemCount
    }

    func testTime_groupBySession() async throws {
        let r1 = makeRecord(name: "S1", activeDurationSeconds: 100, itemCount: 3)
        let r2 = makeRecord(name: "S2", activeDurationSeconds: 200, itemCount: 5)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "session"],
            scanner: mockScanner
        )
        let groups = result["groups"] as? [[String: Any]]
        XCTAssertEqual(groups?.count, 2)

        let s1Group = groups?.first { ($0["key"] as? String) == r1.id.uuidString }
        XCTAssertNotNil(s1Group)
        XCTAssertEqual(s1Group?["sessions"] as? Int, 1)
        XCTAssertEqual(s1Group?["active_duration_seconds"] as? Int, 100)
        XCTAssertEqual(s1Group?["turn_count"] as? Int, 3)
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
        let groups = result["groups"] as? [[String: Any]]
        XCTAssertEqual(groups?.count, 2)

        let alphaGroup = groups?.first { ($0["key"] as? String) == "Alpha" }
        XCTAssertNotNil(alphaGroup)
        XCTAssertEqual(alphaGroup?["sessions"] as? Int, 2)
        XCTAssertEqual(alphaGroup?["active_duration_seconds"] as? Int, 300)
    }

    func testTime_includeDetails() async throws {
        let r1 = makeRecord(name: "S1", activeDurationSeconds: 100, itemCount: 3)
        let r2 = makeRecord(name: "S2", activeDurationSeconds: 200, itemCount: 5)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "workspace", "include_details": true],
            scanner: mockScanner
        )
        let groups = result["groups"] as? [[String: Any]]
        let group = groups?.first
        let details = group?["details"] as? [[String: Any]]
        XCTAssertNotNil(details)
        XCTAssertEqual(details?.count, 2)

        let detailNames = details?.compactMap { $0["session_name"] as? String }
        XCTAssertEqual(detailNames?.sorted(), ["S1", "S2"])
    }

    func testTime_withoutIncludeDetails() async throws {
        let r1 = makeRecord(name: "S1")
        mockScanner.scanResults = [makeScanResult(records: [r1])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "session"],
            scanner: mockScanner
        )
        let groups = result["groups"] as? [[String: Any]]
        XCTAssertNil(groups?.first?["details"])
    }

    func testTime_groupByMonth() async throws {
        let jan = Date(timeIntervalSince1970: 1_700_000_000) // ~Nov 2023
        let feb = jan.addingTimeInterval(30 * 86400)
        let r1 = makeRecord(name: "S1", activeDurationSeconds: 100, savedAt: jan)
        let r2 = makeRecord(name: "S2", activeDurationSeconds: 200, savedAt: jan)
        let r3 = makeRecord(name: "S3", activeDurationSeconds: 300, savedAt: feb)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2, r3])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "month"],
            scanner: mockScanner
        )
        let groups = result["groups"] as? [[String: Any]]
        XCTAssertEqual(groups?.count, 2)
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

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "week"],
            scanner: mockScanner
        )
        XCTAssertEqual(result["total_sessions"] as? Int, 3)
        XCTAssertEqual(result["total_active_duration_seconds"] as? Int, 600)
        XCTAssertEqual(result["truncated"] as? Bool, false)

        let groups = result["groups"] as? [[String: Any]]
        XCTAssertEqual(groups?.count, 2)

        // Find the group with 2 sessions (same week).
        let twoSessionGroup = groups?.first { $0["sessions"] as? Int == 2 }
        XCTAssertNotNil(twoSessionGroup)
        XCTAssertEqual(twoSessionGroup?["active_duration_seconds"] as? Int, 300)
        XCTAssertEqual(twoSessionGroup?["tool_call_count"] as? Int, 0)
    }

    func testTime_sessionFilter() async throws {
        let targetID = UUID()
        let otherID = UUID()
        let r1 = makeRecord(id: targetID, name: "Target", activeDurationSeconds: 100)
        let r2 = makeRecord(id: otherID, name: "Other", activeDurationSeconds: 200)
        mockScanner.scanResults = [makeScanResult(records: [r1, r2])]

        let result = try await HistoryMCPToolService.execute(
            args: ["op": "time", "group_by": "session", "session_id": targetID.uuidString],
            scanner: mockScanner
        )
        XCTAssertEqual(result["total_sessions"] as? Int, 1)
        XCTAssertEqual(result["total_active_duration_seconds"] as? Int, 100)
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

    // MARK: - parseDate

    func testParseDate_acceptsISO8601WithAndWithoutFractionalSeconds() {
        for value in ["2026-06-10T12:00:00Z", "2026-06-10T12:00:00.123Z"] {
            XCTAssertNotNil(HistoryMCPToolService.parseDate(value), value)
        }
    }

    func testParseDate_returnsNilForMissingOrInvalidValues() {
        for value in [nil, "", "not-a-date"] as [String?] {
            XCTAssertNil(HistoryMCPToolService.parseDate(value), value ?? "nil")
        }
    }

    // MARK: - parseDateBound

    private static func utcMidnight(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
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
        let names = ((result["sessions"] as? [[String: Any]]) ?? []).compactMap { $0["session_name"] as? String }
        XCTAssertEqual(Set(names), ["Jun12", "Jun13"], "date_to date-only must include the named day")
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

    // MARK: - Helpers

    private func makeRecord(
        id: UUID = UUID(),
        name: String = "Test Session",
        agentKindRaw: String? = nil,
        agentModelRaw: String? = nil,
        keyPaths: Set<String> = [],
        activeDurationSeconds: Int = 0,
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
            activeDurationSeconds: activeDurationSeconds,
            toolCallCount: toolCallCount
        )
    }

    private func makeScanResult(
        workspaceName: String = "TestWorkspace",
        records: [AgentSessionMetadataRecord] = []
    ) -> HistoryWorkspaceScanResult {
        HistoryWorkspaceScanResult(
            workspaceDir: URL(fileURLWithPath: "/tmp/Workspaces/Workspace-\(workspaceName)-\(UUID().uuidString)"),
            workspaceName: workspaceName,
            workspaceID: UUID(),
            records: records,
            indexReadFailed: false,
            indexSchemaVersion: nil
        )
    }
}

// MARK: - Mock Scanner

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
    var filterRequests: [FilterRequest] = []
    var transcriptProvider: ((UUID) throws -> AgentTranscript)?

    func scanAllWorkspaces() async throws -> [HistoryWorkspaceScanResult] {
        scanResults
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
        return try provider(sessionID)
    }
}
