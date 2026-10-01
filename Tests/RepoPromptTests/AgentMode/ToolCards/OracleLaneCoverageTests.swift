@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class OracleLaneCoverageTests: XCTestCase {
    func testCoverageIsSilentForSingleLaneResults() {
        XCTAssertNil(OracleLaneCoverage(lanes: nil))
        XCTAssertNil(OracleLaneCoverage(lanes: [lane(0, "gpt-6.1-sol", "completed")]))
    }

    func testShortModelNameDropsProviderPrefixes() {
        XCTAssertEqual(OracleLaneCoverage.shortModelName("anthropic/claude-opus-5"), "claude-opus-5")
        XCTAssertEqual(OracleLaneCoverage.shortModelName("claude_code__sonnet:medium"), "sonnet:medium")
        XCTAssertEqual(OracleLaneCoverage.shortModelName(" "), "model")
    }

    func testPartialGroupReportsCoverageAndWarns() throws {
        let coverage = try XCTUnwrap(OracleLaneCoverage(lanes: [
            lane(1, "anthropic/claude-opus-5", "failed", errorCode: "provider_error", errorMessage: "Request timed out after 600s"),
            lane(0, "astra-2", "completed")
        ]))
        XCTAssertEqual(coverage.completedCount, 1)
        XCTAssertEqual(coverage.totalCount, 2)
        XCTAssertEqual(coverage.summaryText, "1/2 lanes · claude-opus-5 timed out")
        XCTAssertEqual(coverage.cardStatus, .warning)
        XCTAssertFalse(coverage.summaryText.lowercased().contains("reconcil"))
    }

    func testCompleteAndFullyFailedGroups() throws {
        let complete = try XCTUnwrap(OracleLaneCoverage(lanes: [
            lane(0, "a", "completed"), lane(1, "b", "completed")
        ]))
        XCTAssertEqual(complete.summaryText, "2/2 lanes")
        XCTAssertNil(complete.cardStatus)

        let failed = try XCTUnwrap(OracleLaneCoverage(lanes: [
            lane(0, "a", "cancelled", errorCode: "cancelled", errorMessage: "Oracle lane was cancelled."),
            lane(1, "b", "failed", errorCode: "empty_response", errorMessage: "Oracle lane returned an empty response."),
            lane(2, "c", "failed", errorCode: "provider_error", errorMessage: "boom")
        ]))
        XCTAssertEqual(failed.summaryText, "0/3 lanes · a cancelled +2")
        XCTAssertEqual(failed.cardStatus, .failure)
        XCTAssertEqual(failed.incompleteLanes.map(\.reason), ["cancelled", "empty response", "failed"])
    }

    func testCompletedContextBuilderOutcomeDoesNotOverstateLaneSuccess() throws {
        let complete = try XCTUnwrap(OracleLaneCoverage(lanes: [lane(0, "a", "completed"), lane(1, "b", "completed")]))
        let partial = try XCTUnwrap(OracleLaneCoverage(lanes: [lane(0, "a", "completed"), lane(1, "b", "failed")]))
        let failed = try XCTUnwrap(OracleLaneCoverage(lanes: [lane(0, "a", "failed"), lane(1, "b", "cancelled")]))
        for label in ["success", "completed"] {
            XCTAssertEqual(contextBuilderCompletedOutcomeLabel(label, coverage: complete, toolIsError: false), label)
            XCTAssertEqual(contextBuilderCompletedOutcomeLabel(label, coverage: partial, toolIsError: false), "partial success")
            XCTAssertEqual(contextBuilderCompletedOutcomeLabel(label, coverage: failed, toolIsError: false), "Oracle incomplete")
            XCTAssertEqual(contextBuilderCompletedOutcomeLabel(label, coverage: partial, toolIsError: true), "error")
        }
        for label in ["error", "failed", "cancelled", "partial"] {
            XCTAssertEqual(contextBuilderCompletedOutcomeLabel(label, coverage: partial, toolIsError: false), label)
        }
    }

    func testPersistedContextBuilderReviewKeepsLaneDigestWithoutResponses() throws {
        let raw: [String: Any] = [
            "context_id": "CA9D86FB-FDA0-482A-8F46-6910C089E853",
            "response_type": "review",
            "status": "success",
            "review": [
                "chat_id": "course-review-34AE57",
                "mode": "review",
                "response": String(repeating: "finding ", count: 2000),
                "oracle_group_id": "6F1E0C55-6C1F-4C1B-9B7E-1C2D3E4F5A6B",
                "status": "partial_failure",
                "oracle_count": 2,
                "oracle_results": [
                    rawLane(0, "astra-2", "completed", response: "long answer"),
                    rawLane(
                        1,
                        "claude_code__opus:high",
                        "failed",
                        profileModel: "claude-opus-5",
                        errorCode: "provider_error",
                        errorMessage: "Request timed out"
                    )
                ]
            ]
        ]
        let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(
            for: AgentChatItem(kind: .toolResult, text: "", toolName: "context_builder", toolResultJSON: jsonString(raw), toolIsError: false)
        ))
        XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
        XCTAssertFalse(summary.resultJSON.contains("finding finding"), summary.resultJSON)
        XCTAssertFalse(summary.resultJSON.contains("long answer"), summary.resultJSON)

        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: summary.resultJSON))
        XCTAssertEqual(dto.review?.chatID, "course-review-34AE57")
        let coverage = try XCTUnwrap(contextBuilderOracleLaneCoverage(for: dto))
        XCTAssertEqual(coverage.summaryText, "1/2 lanes · claude-opus-5 timed out")
        XCTAssertEqual(contextBuilderOracleLaneSummaries(for: dto).map(\.status), ["done", "failed"])

        let reloadedSummary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(
            for: AgentChatItem(kind: .toolResult, text: summary.resultJSON, toolName: "context_builder", toolResultJSON: summary.resultJSON, toolIsError: false)
        ))
        let reloadedDTO = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: reloadedSummary.resultJSON))
        XCTAssertEqual(contextBuilderOracleLaneCoverage(for: reloadedDTO)?.summaryText, coverage.summaryText)

        let item = AgentChatItem(kind: .toolResult, text: jsonString(raw), toolName: "context_builder", toolResultJSON: jsonString(raw), toolIsError: false)
        let execution = try XCTUnwrap(AgentTranscriptToolNormalizer.toolExecution(for: item))
        let activity = AgentTranscriptActivity(from: item, toolExecution: execution)
        var transcript = AgentTranscript(turns: [AgentTranscriptTurn(
            responseSpans: [AgentTranscriptProviderResponseSpan(lifecycle: .completed, startedAt: item.timestamp, completedAt: item.timestamp, activities: [activity])],
            startedAt: item.timestamp,
            completedAt: item.timestamp
        )], nextSequenceIndex: 1)
        for pass in 1 ... 2 {
            let persisted = AgentTranscriptPolicyPipeline.persistedTranscript(from: transcript).transcript
            let encoded = try JSONEncoder().encode(persisted)
            let decoded = try JSONDecoder().decode(AgentTranscript.self, from: encoded)
            let restored = AgentTranscriptPolicyPipeline.runtimeTranscript(decoded)
            let row = try XCTUnwrap((restored.projection.workingRows + restored.projection.archivedRows).first { $0.id == item.id })
            let restoredDTO = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: row.toolResultJSON))
            XCTAssertEqual(contextBuilderOracleLaneCoverage(for: restoredDTO)?.summaryText, coverage.summaryText, "round trip \(pass)")
            XCTAssertFalse(row.toolResultJSON?.contains("finding finding") == true)
            transcript = restored.transcript
        }
    }

    func testPersistedAskOracleKeepsLaneDigest() throws {
        let raw: [String: Any] = [
            "chat_id": "review-chat",
            "mode": "review",
            "response": "primary answer",
            "status": "partial_failure",
            "oracle_count": 2,
            "oracle_results": [
                rawLane(0, "astra-2", "completed", response: "primary answer"),
                rawLane(1, "claude-opus-5", "cancelled", errorCode: "cancelled", errorMessage: "Oracle lane was cancelled.")
            ]
        ]
        let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(
            for: AgentChatItem(kind: .toolResult, text: "", toolName: "ask_oracle", toolResultJSON: jsonString(raw), toolIsError: false)
        ))
        XCTAssertFalse(summary.resultJSON.contains("primary answer"), summary.resultJSON)
        let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: summary.resultJSON))
        XCTAssertEqual(dto.chatID, "review-chat")
        XCTAssertEqual(OracleLaneCoverage(lanes: dto.oracleResults)?.summaryText, "1/2 lanes · claude-opus-5 cancelled")
    }

    func testSingleLanePersistedSummaryIsUnchanged() throws {
        let summary = try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(
            for: AgentChatItem(
                kind: .toolResult,
                text: "",
                toolName: "ask_oracle",
                toolResultJSON: jsonString(["chat_id": "c", "mode": "chat", "response": "x"]),
                toolIsError: false
            )
        ))
        XCTAssertFalse(summary.resultJSON.contains("oracle_results"), summary.resultJSON)
    }

    // MARK: - Helpers

    private func lane(
        _ index: Int,
        _ model: String,
        _ status: String,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) -> ToolResultDTOs.ChatSendDTO.OracleLaneDTO {
        let json = jsonString(rawLane(index, model, status, errorCode: errorCode, errorMessage: errorMessage))
        return ToolJSON.decode(ToolResultDTOs.ChatSendDTO.OracleLaneDTO.self, from: json)!
    }

    private func rawLane(
        _ index: Int,
        _ model: String,
        _ status: String,
        response: String? = nil,
        profileModel: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) -> [String: Any] {
        var lane: [String: Any] = [
            "lane_index": index,
            "role": index == 0 ? "primary" : "additional",
            "chat_id": "chat-\(index)",
            "model_id": model,
            "status": status
        ]
        if let response { lane["response"] = response }
        if let profileModel {
            lane["execution_profile"] = ["provider_id": "provider", "model_id": profileModel, "effective_reasoning_effort": "high"]
        }
        if let errorCode {
            lane["error"] = ["code": errorCode, "message": errorMessage ?? errorCode]
        }
        return lane
    }

    private func jsonString(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
