import Foundation
@testable import RepoPrompt
import XCTest

final class CodexNativeSessionControllerEventRecoveryTests: XCTestCase {
    private static let webSearchAliases = ["search", "web_search", "web_search_request", "google_web_search", "search_web"]

    func testStructuredErrorNotificationRetainsRetryMetadataAndScope() throws {
        let retrying = try XCTUnwrap(CodexNativeSessionController.test_parseErrorNotification(from: [
            "threadId": "thread-1",
            "turnId": "turn-1",
            "error": [
                "message": "reconnecting",
                "willRetry": true
            ]
        ]))
        XCTAssertEqual(retrying.message, "reconnecting")
        XCTAssertEqual(retrying.willRetry, true)
        XCTAssertEqual(retrying.threadID, "thread-1")
        XCTAssertEqual(retrying.turnID, "turn-1")

        let nestedRetry = try XCTUnwrap(CodexNativeSessionController.test_parseErrorNotification(from: [
            "error": [
                "message": "nested retry",
                "details": [
                    "will_retry": true,
                    "thread_id": "thread-2",
                    "turn_id": "turn-2",
                    "item_id": "item-2"
                ]
            ]
        ]))
        XCTAssertEqual(nestedRetry.willRetry, true)
        XCTAssertEqual(nestedRetry.threadID, "thread-2")
        XCTAssertEqual(nestedRetry.turnID, "turn-2")
        XCTAssertEqual(nestedRetry.itemID, "item-2")

        let terminal = try XCTUnwrap(CodexNativeSessionController.test_parseErrorNotification(from: [
            "message": "fatal",
            "will_retry": false
        ]))
        XCTAssertEqual(terminal.willRetry, false)

        let missingMetadata = try XCTUnwrap(CodexNativeSessionController.test_parseErrorNotification(from: [
            "message": "retrying from legacy text"
        ]))
        XCTAssertNil(missingMetadata.willRetry)
    }

    func testProgressOnlyNotificationsRetainLivenessCategoryScopeAndActiveFlags() throws {
        let rows: [(String, CodexNativeSessionController.LivenessActivity.Kind)] = [
            ("thread/status/changed", .threadStatusChanged),
            ("turn/plan/updated", .turnPlanUpdated),
            ("turn/diff/updated", .turnDiffUpdated),
            ("item/plan/delta", .itemPlanDelta),
            ("item/mcpToolCall/progress", .mcpToolProgress),
            ("command/exec/outputDelta", .commandOrProcessOutput),
            ("process/exited", .processExited),
            ("hook/started", .hookLifecycle),
            ("warning", .warning),
            ("deprecationNotice", .deprecationNotice),
            ("serverRequest/resolved", .serverRequestResolved)
        ]

        for (method, expectedKind) in rows {
            let activity = try XCTUnwrap(CodexNativeSessionController.test_parseLivenessActivity(
                method: method,
                params: [
                    "threadId": "thread-1",
                    "turnId": "turn-1",
                    "itemId": "item-1",
                    "status": [
                        "type": "active",
                        "activeFlags": ["waiting_for_user_input"]
                    ],
                    "message": "progress"
                ]
            ), method)
            XCTAssertEqual(activity.kind, expectedKind, method)
            XCTAssertEqual(activity.threadID, "thread-1", method)
            XCTAssertEqual(activity.turnID, "turn-1", method)
            XCTAssertEqual(activity.itemID, "item-1", method)
            XCTAssertEqual(activity.activeFlags, ["waiting_for_user_input"], method)
            XCTAssertEqual(activity.message, "progress", method)
        }
    }

    func testStaleScopedProgressNotificationIsRejectedByRouting() {
        XCTAssertTrue(CodexNativeSessionController.test_shouldDropNotificationForRouting(
            method: "turn/plan/updated",
            params: [
                "threadId": "stale-thread",
                "turnId": "stale-turn"
            ],
            activeThreadID: "active-thread",
            currentTurnID: "active-turn"
        ))
    }

    func testNormalizedCommandExecutionLifecycleParsesAsBashCallAndResult() throws {
        let controller = CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil
        )

        let started = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/started",
            params: [
                "threadId": "thread-active",
                "turnId": "turn-current",
                "item": [
                    "type": "commandExecution",
                    "id": "call_exec_1",
                    "command": "echo hi",
                    "cwd": "/tmp/work",
                    "processId": "47551",
                    "commandActions": [["type": "unknown", "command": "echo hi"]]
                ]
            ]
        ))

        XCTAssertEqual(started.kind, "call")
        XCTAssertEqual(started.name, "bash")
        XCTAssertNotNil(started.invocationID)
        let argsObject = try XCTUnwrap(jsonObject(from: started.argsJSON))
        XCTAssertEqual(argsObject["command"] as? String, "echo hi")
        XCTAssertEqual(argsObject["cwd"] as? String, "/tmp/work")
        XCTAssertEqual(argsObject["processId"] as? String, "47551")
        XCTAssertEqual((argsObject["commandActions"] as? [[String: Any]])?.count, 1)

        let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: [
                "threadId": "thread-active",
                "turnId": "turn-current",
                "item": [
                    "type": "commandExecution",
                    "id": "call_exec_1",
                    "command": "echo hi",
                    "processId": "47551",
                    "status": "completed",
                    "exitCode": 0,
                    "aggregatedOutput": "hi\n"
                ]
            ]
        ))

        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.name, "bash")
        XCTAssertEqual(completed.invocationID, started.invocationID)
        XCTAssertEqual(completed.isError, false)
        let resultObject = try XCTUnwrap(jsonObject(from: completed.resultJSON))
        XCTAssertEqual(resultObject["type"] as? String, "commandExecution")
        XCTAssertEqual(resultObject["status"] as? String, "completed")
        XCTAssertEqual(resultObject["processId"] as? String, "47551")
        XCTAssertEqual(resultObject["aggregatedOutput"] as? String, "hi\n")
        XCTAssertEqual(resultObject["exitCode"] as? Int, 0)
    }

    func testNativeWebSearchAliasesPairStartedAndCompletedInvocations() throws {
        for alias in Self.webSearchAliases {
            let controller = makeController()
            let itemID = "call_pair_\(alias)"
            let started = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/started",
                params: toolParams(item: [
                    "type": "toolCall",
                    "id": itemID,
                    "name": alias,
                    "query": "paired alias \(alias)"
                ])
            ), alias)

            let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: [
                    "type": "toolCall",
                    "id": itemID,
                    "name": alias,
                    "status": "completed",
                    "query": "paired alias \(alias)",
                    "response": [
                        "results": [["title": "Paired", "snippet": alias]]
                    ]
                ])
            ), alias)

            XCTAssertEqual(started.kind, "call", alias)
            XCTAssertEqual(completed.kind, "result", alias)
            XCTAssertEqual(completed.name, "search", alias)
            XCTAssertEqual(completed.invocationID, started.invocationID, alias)
            XCTAssertEqual(completed.isError, false, alias)
        }
    }

    func testNativeWebSearchCompletionPayloadsPreserveCompactSearchFields() throws {
        let rows: [(label: String, alias: String, item: [String: Any], expectedResults: Int?, expectedSources: Int?, expectedDetailKey: String)] = [
            (
                "root results",
                "web_search",
                [
                    "type": "toolCall",
                    "id": "call_search_root",
                    "name": "web_search",
                    "status": "completed",
                    "query": "RepoPrompt CE",
                    "results": [["title": "RepoPrompt CE", "url": "https://example.com/repo", "snippet": "Native cards"]],
                    "sources": [["title": "Docs", "url": "https://example.com/docs"]]
                ],
                1,
                1,
                "results"
            ),
            (
                "wrapped response",
                "web_search_request",
                [
                    "type": "toolCall",
                    "id": "call_search_wrapped",
                    "name": "web_search_request",
                    "query": "macOS app search",
                    "response": [
                        "summary": "Search completed",
                        "items": [["title": "Result", "snippet": "Useful result"]]
                    ],
                    "sources": [["title": "Wrapped Source"]],
                    "total_results": 3,
                    "source_count": 4,
                    "citationCount": 2
                ],
                nil,
                1,
                "items"
            ),
            (
                "array content",
                "google_web_search",
                [
                    "type": "toolCall",
                    "id": "call_search_array",
                    "name": "google_web_search",
                    "query": "Codex native web search",
                    "content": [["title": "Codex", "snippet": "Web search result"]]
                ],
                1,
                nil,
                "results"
            )
        ]

        for row in rows {
            let controller = makeController()
            let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: row.item)
            ), row.label)

            XCTAssertEqual(completed.kind, "result", row.label)
            XCTAssertEqual(completed.name, "search", row.label)
            XCTAssertNotEqual(completed.isError, true, row.label)
            let resultObject = try XCTUnwrap(jsonObject(from: completed.resultJSON), row.label)
            XCTAssertEqual(resultObject["query"] as? String, row.item["query"] as? String, row.label)
            if let expectedResults = row.expectedResults {
                XCTAssertEqual((resultObject["results"] as? [[String: Any]])?.count, expectedResults, row.label)
            }
            if let expectedSources = row.expectedSources {
                XCTAssertEqual((resultObject["sources"] as? [[String: Any]])?.count, expectedSources, row.label)
            }
            XCTAssertNotNil(resultObject[row.expectedDetailKey], row.label)
            if row.label == "wrapped response" {
                XCTAssertEqual(resultObject["total_results"] as? Int, 3)
                XCTAssertEqual(resultObject["source_count"] as? Int, 4)
                XCTAssertEqual(resultObject["citationCount"] as? Int, 2)
            }
        }
    }

    func testNativeWebSearchWrappedPayloadMergesSiblingSearchFieldsAndSuccessfulStatusWins() throws {
        let controller = makeController()
        let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_search_completed_with_stale_error",
                "name": "web_search",
                "status": "completed",
                "query": "completed despite stale error field",
                "response": [
                    "items": [["title": "Completed", "snippet": "Usable result"]]
                ],
                "citations": [["title": "Citation"]],
                "total_results": 9,
                "errorMessage": "stale retry warning",
                "errors": [["message": "stale retry detail"]]
            ])
        ))

        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.name, "search")
        XCTAssertEqual(completed.isError, false)
        let resultObject = try XCTUnwrap(jsonObject(from: completed.resultJSON))
        XCTAssertEqual(resultObject["query"] as? String, "completed despite stale error field")
        XCTAssertEqual((resultObject["items"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((resultObject["citations"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(resultObject["total_results"] as? Int, 9)
        XCTAssertEqual(resultObject["errorMessage"] as? String, "stale retry warning")
        XCTAssertEqual((resultObject["errors"] as? [[String: Any]])?.count, 1)
    }

    func testNativeWebSearchErrorPayloadWithoutFailedStatusParsesAsFailure() throws {
        let controller = makeController()
        let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_search_error_without_status",
                "name": "web_search",
                "query": "transient web outage",
                "errorMessage": "web search timed out"
            ])
        ))

        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.name, "search")
        XCTAssertEqual(completed.isError, true)
        let resultObject = try XCTUnwrap(jsonObject(from: completed.resultJSON))
        XCTAssertEqual(resultObject["query"] as? String, "transient web outage")
        XCTAssertEqual(resultObject["errorMessage"] as? String, "web search timed out")
    }

    private func makeController() -> CodexNativeSessionController {
        CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil
        )
    }

    private func toolParams(item: [String: Any]) -> [String: Any] {
        [
            "threadId": "thread-active",
            "turnId": "turn-current",
            "item": item
        ]
    }

    private func jsonObject(from raw: String?) -> [String: Any]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
