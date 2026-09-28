import Foundation
@testable import RepoPromptApp
import XCTest

/// Devin re-sends `tool_call_update(status: completed)` for a RepoPrompt MCP tool without
/// `rawInput` after the call's row has already completed. That update must settle onto the
/// existing row instead of appending an argument-less duplicate result.
@MainActor
final class ACPToolCompletionDeduplicationTests: XCTestCase {
    func testArgumentlessRepeatCompletionDoesNotAppendDuplicateResultRow() throws {
        let harness = AgentSessionLinkRunnerHarness(
            headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }
        )
        let session = harness.makeSession(agent: .devin)
        let title = "git (\(RepoPromptMCPServerConfiguration.defaultServerName))"
        let rawInput: [String: Any] = ["op": "log", "count": 10]
        let richOutput = #"{"op":"log","commits":[{"sha":"84fb49f0d"}]}"#
        let updates: [[String: Any]] = [
            ["sessionUpdate": "tool_call", "toolCallId": "tc-git-1", "title": title, "status": "pending", "rawInput": rawInput],
            [
                "sessionUpdate": "tool_call_update",
                "toolCallId": "tc-git-1",
                "title": title,
                "status": "completed",
                "rawInput": rawInput,
                "rawOutput": richOutput
            ],
            [
                "sessionUpdate": "tool_call_update",
                "toolCallId": "tc-git-1",
                "title": title,
                "status": "completed",
                "rawOutput": "ok"
            ]
        ]

        for update in updates {
            for case let .stream(result) in ACPDefaultSessionUpdateNormalizer.normalize(update, providerID: .devin) {
                XCTAssertTrue(harness.service.handleProviderToolStreamEvent(result, session: session))
            }
        }

        let invocationID = ACPRuntimeEventParsing.stableInvocationUUID(rawValue: "tc-git-1")
        let toolRows = session.items.filter { $0.toolInvocationID == invocationID }
        XCTAssertEqual(toolRows.count, 1, "rows: \(toolRows.map { ($0.kind, $0.toolArgsJSON, $0.toolResultJSON) })")
        let row = try XCTUnwrap(toolRows.first)
        XCTAssertEqual(row.kind, .toolResult)
        XCTAssertNotNil(row.toolArgsJSON)
        XCTAssertEqual(row.toolResultJSON, richOutput)
    }
}
