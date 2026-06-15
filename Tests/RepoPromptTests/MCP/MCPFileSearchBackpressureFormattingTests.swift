import MCP
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPFileSearchBackpressureFormattingTests: XCTestCase {
    func testQueueFullMapsToMachineReadableRetryableDTO() throws {
        let dto = MCPFileToolProvider.searchBackpressureDTO(
            for: .queueFull(scope: .perStore, retryAfterMilliseconds: 1250)
        )

        XCTAssertEqual(dto.errorCode, "search_backpressure")
        XCTAssertEqual(dto.retryable, true)
        XCTAssertEqual(dto.retryAfterMilliseconds, 1250)
        XCTAssertTrue(dto.errorMessage?.contains("temporarily busy") == true)
        XCTAssertTrue(dto.suggestion?.contains("filter.paths") == true)

        let object = try XCTUnwrap(Self.value(dto).objectValue)
        XCTAssertEqual(object["error_code"]?.stringValue, "search_backpressure")
        XCTAssertEqual(object["retryable"]?.boolValue, true)
        XCTAssertEqual(object["retry_after_ms"]?.intValue, 1250)
    }

    func testWaitExpiredUsesTheSameRetryableBackpressureClassification() {
        let dto = MCPFileToolProvider.searchBackpressureDTO(
            for: .waitExpired(retryAfterMilliseconds: 2000)
        )

        XCTAssertEqual(dto.errorCode, "search_backpressure")
        XCTAssertEqual(dto.retryable, true)
        XCTAssertEqual(dto.retryAfterMilliseconds, 2000)
        XCTAssertTrue(dto.errorMessage?.contains("wait expired") == true)
    }

    func testContentReadQueueFullMapsToMachineReadableRetryableDTO() {
        let dto = MCPFileToolProvider.searchBackpressureDTO(
            for: .contentReadQueueFull(retryAfterMilliseconds: 750)
        )

        XCTAssertEqual(dto.errorCode, "search_backpressure")
        XCTAssertEqual(dto.retryable, true)
        XCTAssertEqual(dto.retryAfterMilliseconds, 750)
        XCTAssertTrue(dto.errorMessage?.contains("Content-read capacity") == true)
    }

    func testRetryableBackpressureFormatsAsTemporaryBusyInsteadOfZeroMatches() throws {
        let dto = MCPFileToolProvider.searchBackpressureDTO(
            for: .queueFull(scope: .perStore, retryAfterMilliseconds: 1000)
        )

        let text = try Self.onlyText(ToolOutputFormatter.formatSearch(value: Self.value(dto)))

        XCTAssertTrue(text.contains("## Search Results ⚠️"), text)
        XCTAssertTrue(text.contains("**Status**: Temporarily busy"), text)
        XCTAssertTrue(text.contains("**Code**: search_backpressure"), text)
        XCTAssertTrue(text.contains("**Retryable**: yes"), text)
        XCTAssertTrue(text.contains("**Retry after**: 1000 ms"), text)
        XCTAssertTrue(text.contains("filter.paths"), text)
        XCTAssertFalse(text.contains("Total matches"), text)
        XCTAssertFalse(text.contains("Complete (limit not reached)"), text)
    }

    func testUnavailableWorktreeMapsToTypedRetryableDTOAndWarningFormatting() throws {
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

        XCTAssertEqual(dto.errorCode, "worktree_scope_unavailable")
        XCTAssertEqual(dto.retryable, true)
        XCTAssertEqual(dto.retryAfterMilliseconds, 1000)
        XCTAssertEqual(dto.worktreeScope, scope)
        XCTAssertTrue(dto.errorMessage?.contains("base workspace was intentionally not searched") == true)

        let text = try Self.onlyText(ToolOutputFormatter.formatSearch(value: Self.value(dto)))
        XCTAssertTrue(text.contains("## Search Results ⚠️"), text)
        XCTAssertTrue(text.contains("**Status**: Worktree unavailable"), text)
        XCTAssertTrue(text.contains("**Retryable**: yes"), text)
        XCTAssertTrue(text.contains("project-agent"), text)
        XCTAssertFalse(text.contains("Total matches"), text)
    }

    func testFreshnessTimeoutMapsToDistinctRetryableDTOAndWarningFormatting() throws {
        let dto = MCPFileToolProvider.searchRetryableFailureDTO(
            for: .workspaceFreshnessTimedOut
        )

        XCTAssertEqual(dto.errorCode, "workspace_freshness_timeout")
        XCTAssertEqual(dto.retryable, true)
        XCTAssertEqual(dto.retryAfterMilliseconds, 1000)
        XCTAssertTrue(dto.errorMessage?.contains("Workspace freshness timed out") == true)

        let object = try XCTUnwrap(Self.value(dto).objectValue)
        XCTAssertEqual(object["error_code"]?.stringValue, "workspace_freshness_timeout")
        XCTAssertEqual(object["retryable"]?.boolValue, true)

        let text = try Self.onlyText(ToolOutputFormatter.formatSearch(value: Self.value(dto)))
        XCTAssertTrue(text.contains("## Search Results ⚠️"), text)
        XCTAssertTrue(text.contains("**Status**: Workspace freshness timed out"), text)
        XCTAssertTrue(text.contains("**Code**: workspace_freshness_timeout"), text)
        XCTAssertFalse(text.contains("Worktree unavailable"), text)
        XCTAssertFalse(text.contains("Total matches"), text)
    }

    func testPatternFailureFormattingRemainsNonRetryable() throws {
        let dto = Self.errorDTO(
            errorMessage: "Invalid regular expression.",
            suggestion: "Use regex=false for literal matching."
        )

        let text = try Self.onlyText(ToolOutputFormatter.formatSearch(value: Self.value(dto)))

        XCTAssertTrue(text.contains("## Search Results ❌"), text)
        XCTAssertTrue(text.contains("Invalid regular expression."), text)
        XCTAssertTrue(text.contains("Use regex=false"), text)
        XCTAssertFalse(text.contains("Temporarily busy"), text)
        XCTAssertFalse(text.contains("Retryable"), text)
    }

    func testNormalSearchDTOOmitsOptionalBackpressureFields() throws {
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

        let object = try XCTUnwrap(Self.value(dto).objectValue)
        XCTAssertNil(object["error_code"])
        XCTAssertNil(object["retryable"])
        XCTAssertNil(object["retry_after_ms"])
        let text = try Self.onlyText(ToolOutputFormatter.formatSearch(value: Self.value(dto)))
        XCTAssertTrue(text.contains("Complete (limit not reached)"), text)
        XCTAssertFalse(text.contains("Temporarily busy"), text)
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

    private static func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
        let first = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = first else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }
}
