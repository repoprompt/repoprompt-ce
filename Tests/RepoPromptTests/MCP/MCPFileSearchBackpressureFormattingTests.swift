import MCP
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPFileSearchBackpressureFormattingTests: XCTestCase {
    func testSearchBackpressureDTOAndFormatterPreserveRetryableClassificationMatrix() throws {
        do {
            let caseLabel = "testQueueFullMapsToMachineReadableRetryableDTO"
            let dto = MCPFileToolProvider.searchBackpressureDTO(
                for: .queueFull(scope: .perStore, retryAfterMilliseconds: 1250)
            )

            XCTAssertEqual(dto.errorCode, "search_backpressure", caseLabel)
            XCTAssertEqual(dto.retryable, true, caseLabel)
            XCTAssertEqual(dto.retryAfterMilliseconds, 1250, caseLabel)
            XCTAssertTrue(dto.errorMessage?.contains("temporarily busy") == true, caseLabel)
            XCTAssertTrue(dto.suggestion?.contains("filter.paths") == true, caseLabel)

            let object = try XCTUnwrap(Self.value(dto).objectValue, caseLabel)
            XCTAssertEqual(object["error_code"]?.stringValue, "search_backpressure", caseLabel)
            XCTAssertEqual(object["retryable"]?.boolValue, true, caseLabel)
            XCTAssertEqual(object["retry_after_ms"]?.intValue, 1250, caseLabel)
        }

        do {
            let caseLabel = "testWaitExpiredUsesTheSameRetryableBackpressureClassification"
            let dto = MCPFileToolProvider.searchBackpressureDTO(
                for: .waitExpired(retryAfterMilliseconds: 2000)
            )

            XCTAssertEqual(dto.errorCode, "search_backpressure", caseLabel)
            XCTAssertEqual(dto.retryable, true, caseLabel)
            XCTAssertEqual(dto.retryAfterMilliseconds, 2000, caseLabel)
            XCTAssertTrue(dto.errorMessage?.contains("wait expired") == true, caseLabel)
        }

        do {
            let caseLabel = "testContentReadQueueFullMapsToMachineReadableRetryableDTO"
            let dto = MCPFileToolProvider.searchBackpressureDTO(
                for: .contentReadQueueFull(retryAfterMilliseconds: 750)
            )

            XCTAssertEqual(dto.errorCode, "search_backpressure", caseLabel)
            XCTAssertEqual(dto.retryable, true, caseLabel)
            XCTAssertEqual(dto.retryAfterMilliseconds, 750, caseLabel)
            XCTAssertTrue(dto.errorMessage?.contains("Content-read capacity") == true, caseLabel)
        }

        do {
            let caseLabel = "testRetryableBackpressureFormatsAsTemporaryBusyInsteadOfZeroMatches"
            let dto = MCPFileToolProvider.searchBackpressureDTO(
                for: .queueFull(scope: .perStore, retryAfterMilliseconds: 1000)
            )

            let text = try Self.onlyText(ToolOutputFormatter.formatSearch(value: Self.value(dto)), label: caseLabel)

            XCTAssertTrue(text.contains("## Search Results ⚠️"), caseLabel + ": " + text)
            XCTAssertTrue(text.contains("**Status**: Temporarily busy"), caseLabel + ": " + text)
            XCTAssertTrue(text.contains("**Code**: search_backpressure"), caseLabel + ": " + text)
            XCTAssertTrue(text.contains("**Retryable**: yes"), caseLabel + ": " + text)
            XCTAssertTrue(text.contains("**Retry after**: 1000 ms"), caseLabel + ": " + text)
            XCTAssertTrue(text.contains("filter.paths"), caseLabel + ": " + text)
            XCTAssertFalse(text.contains("Total matches"), caseLabel + ": " + text)
            XCTAssertFalse(text.contains("Complete (limit not reached)"), caseLabel + ": " + text)
        }
    }

    func testRetryableSearchFailuresPreserveTypedDTOAndWarningFormatting() throws {
        do {
            let caseLabel = "testUnavailableWorktreeMapsToTypedRetryableDTOAndWarningFormatting"
            let scope = ToolResultDTOs.WorktreeScopeDTO(
                kind: "session_bound_worktree",
                displayIdentity: "logical_canonical_root",
                effectiveIdentity: "bound_worktree_root",
                rootMappings: [
                    .init(
                        logicalRootName: "Project",
                        logicalRootPath: "/repo/project",
                        effectiveRootName: "project-agent",
                        effectiveRootPath: "/tmp/worktrees/project-agent",
                        worktreeID: "wt-1",
                        worktreeName: "project-agent",
                        branch: "feature/search",
                        label: "Search Worktree"
                    )
                ]
            )
            let dto = MCPFileToolProvider.searchRetryableFailureDTO(
                for: .worktreeScopeUnavailable(missingPhysicalRootPaths: ["/tmp/worktrees/project-agent"]),
                worktreeScope: scope
            )

            XCTAssertEqual(dto.errorCode, "worktree_scope_unavailable", caseLabel)
            XCTAssertEqual(dto.retryable, true, caseLabel)
            XCTAssertEqual(dto.retryAfterMilliseconds, 1000, caseLabel)
            XCTAssertEqual(dto.worktreeScope, scope, caseLabel)
            XCTAssertTrue(dto.errorMessage?.contains("base workspace was intentionally not searched") == true, caseLabel)

            let text = try Self.onlyText(ToolOutputFormatter.formatSearch(value: Self.value(dto)), label: caseLabel)
            XCTAssertTrue(text.contains("## Search Results ⚠️"), caseLabel + ": " + text)
            XCTAssertTrue(text.contains("**Status**: Worktree unavailable"), caseLabel + ": " + text)
            XCTAssertTrue(text.contains("**Retryable**: yes"), caseLabel + ": " + text)
            XCTAssertTrue(text.contains("project-agent"), caseLabel + ": " + text)
            XCTAssertFalse(text.contains("Total matches"), caseLabel + ": " + text)
        }

        do {
            let caseLabel = "testFreshnessTimeoutMapsToDistinctRetryableDTOAndWarningFormatting"
            let dto = MCPFileToolProvider.searchRetryableFailureDTO(
                for: .workspaceFreshnessTimedOut
            )

            XCTAssertEqual(dto.errorCode, "workspace_freshness_timeout", caseLabel)
            XCTAssertEqual(dto.retryable, true, caseLabel)
            XCTAssertEqual(dto.retryAfterMilliseconds, 1000, caseLabel)
            XCTAssertTrue(dto.errorMessage?.contains("Workspace freshness timed out") == true, caseLabel)

            let object = try XCTUnwrap(Self.value(dto).objectValue, caseLabel)
            XCTAssertEqual(object["error_code"]?.stringValue, "workspace_freshness_timeout", caseLabel)
            XCTAssertEqual(object["retryable"]?.boolValue, true, caseLabel)

            let text = try Self.onlyText(ToolOutputFormatter.formatSearch(value: Self.value(dto)), label: caseLabel)
            XCTAssertTrue(text.contains("## Search Results ⚠️"), caseLabel + ": " + text)
            XCTAssertTrue(text.contains("**Status**: Workspace freshness timed out"), caseLabel + ": " + text)
            XCTAssertTrue(text.contains("**Code**: workspace_freshness_timeout"), caseLabel + ": " + text)
            XCTAssertFalse(text.contains("Worktree unavailable"), caseLabel + ": " + text)
            XCTAssertFalse(text.contains("Total matches"), caseLabel + ": " + text)
        }
    }

    func testNonRetryableAndNormalSearchFormattingOmitBackpressureSemantics() throws {
        do {
            let caseLabel = "testPatternFailureFormattingRemainsNonRetryable"
            let dto = Self.errorDTO(
                errorMessage: "Invalid regular expression.",
                suggestion: "Use regex=false for literal matching."
            )

            let text = try Self.onlyText(ToolOutputFormatter.formatSearch(value: Self.value(dto)), label: caseLabel)

            XCTAssertTrue(text.contains("## Search Results ❌"), caseLabel + ": " + text)
            XCTAssertTrue(text.contains("Invalid regular expression."), caseLabel + ": " + text)
            XCTAssertTrue(text.contains("Use regex=false"), caseLabel + ": " + text)
            XCTAssertFalse(text.contains("Temporarily busy"), caseLabel + ": " + text)
            XCTAssertFalse(text.contains("Retryable"), caseLabel + ": " + text)
        }

        do {
            let caseLabel = "testNormalSearchDTOOmitsOptionalBackpressureFields"
            let dto = ToolResultDTOs.SearchResultDTO(
                totalMatches: 0,
                totalFiles: 0,
                contentMatches: 0,
                pathMatches: 0,
                limitHit: false,
                perFileCounts: [],
                pathMatchLines: [],
                contentMatchGroups: []
            )

            let object = try XCTUnwrap(Self.value(dto).objectValue, caseLabel)
            XCTAssertNil(object["error_code"], caseLabel)
            XCTAssertNil(object["retryable"], caseLabel)
            XCTAssertNil(object["retry_after_ms"], caseLabel)
            let text = try Self.onlyText(ToolOutputFormatter.formatSearch(value: Self.value(dto)), label: caseLabel)
            XCTAssertTrue(text.contains("Complete (limit not reached)"), caseLabel + ": " + text)
            XCTAssertFalse(text.contains("Temporarily busy"), caseLabel + ": " + text)
        }
    }

    private static func errorDTO(
        errorMessage: String,
        suggestion: String
    ) -> ToolResultDTOs.SearchResultDTO {
        ToolResultDTOs.SearchResultDTO(
            totalMatches: 0,
            totalFiles: 0,
            contentMatches: 0,
            pathMatches: 0,
            limitHit: false,
            perFileCounts: [],
            pathMatchLines: [],
            contentMatchGroups: [],
            errorMessage: errorMessage,
            suggestion: suggestion
        )
    }

    private static func value(_ value: some Encodable) throws -> Value {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func onlyText(
        _ blocks: [MCP.Tool.Content],
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let first = try XCTUnwrap(blocks.first, label, file: file, line: line)
        guard case let .text(text, _, _) = first else {
            XCTFail(label + ": Expected text content", file: file, line: line)
            return ""
        }
        return text
    }
}
